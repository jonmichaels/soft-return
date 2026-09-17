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
public enum RenderStyle: String, Hashable, CaseIterable, Sendable {
    /// Line-for-line typescript reproduction: Courier, the file's own page geometry.
    ///
    /// Called `printed` until planning #265 (Jon: "Native view should be referenced with
    /// some kind of 'native' label and Printed views should have 'printed' label. Even in
    /// internal code"). This case is the AppKit facsimile pass — `DocumentRenderer
    /// .renderNative` — so it is Native. The name it maps to on the library's side stays
    /// `EmitMode.printed`, because that IS the engine's Printed output; `emitMode` below is
    /// where the two vocabularies meet, and it is the only place they should.
    case native
    /// Reflowed to a modern page: fixed 1in margins, the user's font and size.
    case modern

    public var displayName: String {
        switch self {
        case .native: return "Native"
        case .modern: return "Modern"
        }
    }

    /// The library's own mode enum, for handing to emitters.
    public var emitMode: EmitMode {
        switch self {
        case .native:  return .printed
        case .modern:  return .modern
        }
    }

    /// This export style, projected onto the window's three-case view axis — the mapping
    /// `PagePreviewRenderer` uses to keep a batch preview's `DocumentState.style` honest
    /// about what it is a preview OF, even though a preview is never shown in Native.
    public var viewStyle: ViewStyle {
        switch self {
        case .native: return .native
        case .modern: return .modern
        }
    }
}

/// How the DOCUMENT WINDOW currently shows the page — the vocabulary the View menu, the
/// bottom bar's Style popup, and Settings' Default Style all use (job 265, decision register
/// 2026-08-12). Three cases, not two: `RenderStyle` above (unchanged) is what export/convert
/// still speaks, because Native has no export meaning.
public enum ViewStyle: String, Hashable, CaseIterable, Sendable {
    /// Today's on-screen renderer: AppKit, Mac-mapped fonts, selectable text, Show
    /// Invisibles' reflow. Was called "Printed" before job 265 — RENAMED, not changed in
    /// substance: it is still `DocumentRenderer.renderNative`'s facsimile layout, just
    /// under its honest name now that "Printed" means something more literal (below).
    case native
    /// The engine's own PDF (`emitPDF(doc, mode: .printed)`), shown in a `PDFView` — byte-
    /// for-byte what `sr --mode printed` writes. No AppKit rendering at all; no Show
    /// Invisibles (a baked PDF cannot reflow).
    case printed
    /// Reflowed for a modern audience — unchanged by this job.
    case modern

    public var displayName: String {
        switch self {
        case .native:  return "Native"
        case .printed: return "Printed"
        case .modern:  return "Modern"
        }
    }

    /// What this view corresponds to for "export what you see": Native and Printed both mean
    /// the facsimile (one shows it via AppKit, the other via the engine's literal PDF, but
    /// exporting either one means a facsimile export), Modern maps straight across.
    public var renderStyle: RenderStyle {
        switch self {
        case .native, .printed: return .native
        case .modern:           return .modern
        }
    }
}

/// Single Page or Continuous Scroll — how many pages are on screen at once.
public enum PageDisplay: String, Hashable, CaseIterable, Sendable {
    case singlePage
    case continuousScroll

    public var displayName: String {
        switch self {
        case .singlePage:       return "Single Page"
        case .continuousScroll: return "Continuous Scroll"
        }
    }
}

/// The zoom control's value. `fit` and `actual` are named states rather than percentages
/// because they must survive a window resize — "Fit" stays fit when the window changes
/// size, where a frozen 87% would not.
public enum ZoomSetting: Hashable, Sendable {
    case fit
    case actual
    case percent(Int)

    /// The steps the bottom-bar menu and View ▸ Zoom In/Out walk through, per the spec's
    /// "50–200% steps".
    public static let steps = [50, 75, 100, 125, 150, 175, 200]

    /// The one place a zoom's name is written, on both platforms (#271 M4: "Actual Size", as the
    /// iPhone already read). The iPhone's own word for Fit is "Fit Width".
    public var displayName: String {
        switch self {
        case .fit:              return "Fit"
        case .actual:           return "Actual Size"
        case .percent(let pct): return "\(pct)%"
        }
    }

    /// The scale to draw at. `fit` asks how large a page would have to be to fill
    /// `fitScale`'s viewport; `actual` and every `percent` both scale RELATIVE TO
    /// `actualScale` — the display's own physical points-per-inch over PostScript's 72, i.e.
    /// true size against a ruler (see `ActualSizeMagnification`) — because Jon's spec makes
    /// "Actual Size" the 100% mark, not a screen that happens to run at exactly 72 real
    /// points per inch. `.actual` is exactly `.percent(100)`: one path, two labels.
    public func scale(fitScale: Double, actualScale: Double = 1.0) -> Double {
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
public enum NamedPageSize: String, Hashable, CaseIterable, Sendable {
    case usLetter
    case usLegal
    case a4

    public var displayName: String {
        switch self {
        case .usLetter: return "US Letter"
        case .usLegal:  return "US Legal"
        case .a4:       return "A4"
        }
    }

    /// Short form for the bottom bar, where the spec's examples read "Legal (Detected)"
    /// and "Letter (Default)" — no "US".
    public var shortName: String {
        switch self {
        case .usLetter: return "Letter"
        case .usLegal:  return "Legal"
        case .a4:       return "A4"
        }
    }

    /// Physical size in points.
    public var sizeInPoints: CGSize {
        switch self {
        case .usLetter: return CGSize(width: 612, height: 792)
        case .usLegal:  return CGSize(width: 612, height: 1008)
        case .a4:       return CGSize(width: 595, height: 842)
        }
    }

    /// The Get-Info-style one-liner the batch window's info panel shows.
    public var dimensionDescription: String {
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
    public static func matching(libraryName: String) -> NamedPageSize? {
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
public final class DocumentState {
    /// The bytes as they arrived. Kept because changing the variant re-parses from scratch
    /// — WordStar variants are different enough that there is no cheap conversion between
    /// two parses of the same file.
    public let data: [UInt8]

    /// What the detector said when the file was opened, before any override. Kept so the
    /// Variant control can offer "Auto" as a way back. A document still awaiting its parse
    /// (`init(awaitingParseOf:)`) holds a placeholder until `adopt(_:)`.
    public private(set) var detection: Detection

    /// Batch 26 (#271 M7): true from `init(awaitingParseOf:)` until `adopt(_:)` or a variant
    /// change parses the bytes — the window is on screen, and `document` is an empty placeholder.
    public private(set) var isAwaitingParse = false

    /// What reading a document's bytes produces: the detector's answer, the parse, and the
    /// pictures resolved against its path. `Sendable`, so it can be made off the main thread
    /// (`parsed(from:docPath:)`) and handed to `adopt(_:)`.
    public struct Parsed: Sendable {
        public let detection: Detection
        /// The parse with `quirks` applied.
        public let document: CtrlKD.Document
        public let pixResults: [PixResult]
        /// Batch 46: the parse before any quirk, and the quirks `document` was made with.
        public let unquirked: CtrlKD.Document
        public let quirks: QuirkChoices
    }

    /// `init(data:settings:docPath:)`'s engine work — detect, parse, resolve the pictures — with
    /// no state of its own, so a large file can be read on another thread while its window shows.
    /// - Throws: whatever `init(data:settings:docPath:)` would.
    public nonisolated static func parsed(from data: [UInt8], docPath: String,
                                          quirks: QuirkChoices = .shipped) throws -> Parsed {
        let detection = detect(data)
        let unquirked = try CtrlKD.parse(data, variant: detection.variant)
        let document = quirks.apply(to: unquirked)
        return Parsed(detection: detection, document: document,
                      pixResults: DocumentPictures.resolve(document, docPath: docPath),
                      unquirked: unquirked, quirks: quirks)
    }

    /// Batch 46 (Jon's quirks rulings, 2026-09-16): the parse before any quirk — what `document` is remade from when
    /// the quirks change.
    private var unquirkedDocument: CtrlKD.Document

    /// The app's default quirks, from Settings when the document opened and whenever they change after.
    public private(set) var quirkDefaults: QuirkChoices

    /// This document's own choices over `quirkDefaults`, by quirk name. Empty is "Use App Defaults".
    public private(set) var quirkOverrides: [String: Bool] = [:]

    /// The quirks in force: the defaults with this document's own choices over them.
    public var quirkChoices: QuirkChoices { quirkDefaults.overridden(by: quirkOverrides) }

    /// The quirks this document trips, the engine's order — the only ones a document's Quirks screen lists.
    public var applicableQuirks: [QuirkApplicability] { QuirkRegistry.standard.applicable(to: unquirkedDocument) }

    /// Whether this document's own choice for `name` differs from the app's default.
    public func isQuirkOverridden(_ name: String) -> Bool {
        guard let on = quirkOverrides[QuirkRegistry.canonicalName(name)] else { return false }
        return on != quirkDefaults.isOn(name)
    }

    /// Turns one quirk on or off for this document. A choice that matches the app's default is no choice of the
    /// document's own. Returns whether the quirks in force changed, so the caller knows to re-render.
    @discardableResult
    public func setQuirk(_ name: String, on: Bool) -> Bool {
        var overrides = quirkOverrides
        overrides[name] = on == quirkDefaults.isOn(name) ? nil : on
        return setQuirkOverrides(overrides)
    }

    /// Replaces this document's own choices — a stored set read back when the document opens, or none.
    @discardableResult
    public func setQuirkOverrides(_ overrides: [String: Bool]) -> Bool {
        let before = quirkChoices
        // A document's choices 4.4.0 stored under the old quirk names are read under the new (batch 47, E5c).
        var canonical: [String: Bool] = [:]
        for (name, on) in overrides { canonical[QuirkRegistry.canonicalName(name)] = on }
        quirkOverrides = canonical.filter { QuirkChoices.names.contains($0.key) }
        return reapplyQuirks(ifChangedFrom: before)
    }

    /// "Use App Defaults": clears this document's own choices.
    @discardableResult
    public func useAppDefaultQuirks() -> Bool { setQuirkOverrides([:]) }

    /// New app defaults, from Settings. This document's own choices stay its own.
    @discardableResult
    public func setQuirkDefaults(_ defaults: QuirkChoices) -> Bool {
        let before = quirkChoices
        quirkDefaults = defaults
        return reapplyQuirks(ifChangedFrom: before)
    }

    private func reapplyQuirks(ifChangedFrom before: QuirkChoices) -> Bool {
        guard quirkChoices != before else { return false }
        // A document still being read has no parse to remake; `adopt(_:)` applies the set in force then.
        guard !isAwaitingParse else { return true }
        document = quirkChoices.apply(to: unquirkedDocument)
        return true
    }

    /// The parse currently on screen, with the quirks in force applied. Recomputed whenever `variant` or the quirks
    /// change.
    public private(set) var document: CtrlKD.Document

    /// Job 371 item 1 (PIX IN VIEWS): the source document's own path, empty when there is
    /// none (bytes-only construction — a synthetic/test `DocumentState`, or a caller that
    /// never had a real file). Same role as `DocumentOperations.ConversionOptions.docPath` —
    /// see that field's own doc comment for why `.PIX` resolution needs it.
    public let docPath: String
    /// `.PIX` tags resolved against `docPath`, once per parse — reused by every view
    /// (`DocumentRenderer`'s Printed/Native/Modern paths, `DocumentWindowController`'s
    /// `pdfView`) so decoding an image never repeats per render call. Recomputed alongside
    /// `document` whenever the variant changes (`setVariant`/`resetVariantToAuto`) — a
    /// different variant is a different parse, so `doc.graphics` is re-read from it, not
    /// assumed unchanged.
    public private(set) var pixResults: [PixResult]

    /// Which parser produced `document`, and whether the user picked it.
    public private(set) var variant: Resolved<Variant>

    public var style: Resolved<ViewStyle>
    public var zoom: Resolved<ZoomSetting>
    public var display: Resolved<PageDisplay>

    /// The paper the document is shown on. Detected from the file's own geometry where it
    /// declared any; otherwise the Settings fallback.
    public private(set) var pageSize: Resolved<NamedPageSize?>

    /// Printed-mode page-geometry override — the footer's Margins control (job 203).
    /// `nil` is "Embedded" (job 315: was "From Document"), the app's long-standing, unchanged
    /// default: whatever the
    /// file's own dot commands declared, filled in with WordStar's factory geometry for
    /// anything the file left unsaid. A non-nil preset flows through `effectivePage` in both
    /// `DocumentRenderer.renderNative` (screen) and `ExportEngine.render` (Printed-mode PDF
    /// export) — the SAME channel the CLI's own `--page-settings` flag uses, so a preset
    /// chosen here can never disagree with what `sr --page-settings <name>` would produce for
    /// the same file. Jon's ruling (2026-08-10): no corpus gets a hardcoded default of its
    /// own — a document with no set margins keeps showing WordStar standard unless a person
    /// picks something else, here, by hand.
    public private(set) var pageSettingsPreset: Resolved<DocumentOperations.PageSettingsPreset?> = Resolved(nil, .default)

    /// View ▸ Show Invisibles. One switch for all of WordStar's own marks — the spec is
    /// explicit that there are no per-kind toggles.
    public var showInvisibles: Bool = false

    /// Modern style's typeface, from Settings. Native and Printed ignore both (each is
    /// Courier at the file's own `.cw` size, by definition).
    public var modernFontName: String
    public var modernFontSize: Int

    /// - Throws: `ParseError.notConvertible` when the bytes aren't a document the library
    ///   can read — the app turns that into the standard "can't open" alert rather than
    ///   showing an empty window.
    public init(data: [UInt8], settings: SettingsStore, docPath: String = "") throws {
        self.data = data
        self.docPath = docPath
        let detection = detect(data)
        self.detection = detection
        self.variant = Resolved(detection.variant, .detected)
        let unquirked = try parse(data, variant: detection.variant)
        let parsed = settings.quirkDefaults.apply(to: unquirked)
        self.unquirkedDocument = unquirked
        self.quirkDefaults = settings.quirkDefaults
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

    /// Batch 26 (#271 M7): a document whose bytes are read and whose parse is still to come —
    /// `WSDocument` opens a large file's window on this at once and parses off the main thread
    /// (`parsed(from:docPath:)`), then calls `adopt(_:)`. Until then `document` is an empty
    /// placeholder, the variant and page size are the defaults, and `isAwaitingParse` is true.
    public init(awaitingParseOf data: [UInt8], settings: SettingsStore, docPath: String = "") {
        self.data = data
        self.docPath = docPath
        self.detection = Detection(variant: .ws4)
        self.variant = Resolved(.ws4, .detected)
        self.document = CtrlKD.Document()
        self.unquirkedDocument = CtrlKD.Document()
        self.quirkDefaults = settings.quirkDefaults
        self.pixResults = []
        self.style = Resolved(settings.defaultStyle, .default)
        self.zoom = Resolved(settings.defaultZoom, .default)
        self.display = Resolved(settings.defaultDisplay, .default)
        self.modernFontName = settings.modernFontName
        self.modernFontSize = settings.modernFontSize
        self.pageSize = Resolved(settings.defaultPageSize, .default)
        self.isAwaitingParse = true
    }

    /// The parse a document awaiting one was opened for: detection, variant, parse, pictures and
    /// the file's own page size, exactly as `init(data:settings:docPath:)` sets them. A style,
    /// zoom or display chosen meanwhile is kept, and so is a page size chosen by hand. Nothing
    /// happens once the document is parsed — a variant change may have parsed it first.
    public func adopt(_ parsed: Parsed) {
        guard isAwaitingParse else { return }
        isAwaitingParse = false
        detection = parsed.detection
        variant = Resolved(parsed.detection.variant, .detected)
        unquirkedDocument = parsed.unquirked
        // The quirks may have changed while the bytes were read — Settings, or a stored choice of the document's own.
        document = parsed.quirks == quirkChoices ? parsed.document : quirkChoices.apply(to: parsed.unquirked)
        pixResults = parsed.pixResults
        refreshPageSizeAfterReparse()
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
    public init(document: CtrlKD.Document, settings: SettingsStore, docPath: String = "") {
        self.data = []
        self.docPath = docPath
        self.detection = Detection(variant: .ws4)
        self.variant = Resolved(.ws4, .detected)
        self.unquirkedDocument = document
        self.quirkDefaults = settings.quirkDefaults
        self.document = settings.quirkDefaults.apply(to: document)
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
    public func setVariant(_ newVariant: Variant) -> Error? {
        do {
            let reparsed = try parse(data, variant: newVariant)
            variant.setManually(newVariant)
            // A variant chosen before the background parse returned (restoration) parses the bytes
            // itself; that parse then has nothing to adopt.
            isAwaitingParse = false
            unquirkedDocument = reparsed
            document = quirkChoices.apply(to: reparsed)
            pixResults = DocumentPictures.resolve(reparsed, docPath: docPath)
            refreshPageSizeAfterReparse()
            return nil
        } catch {
            return error
        }
    }

    /// Return to the detector's own answer. Cannot fail: this parse already succeeded once,
    /// in `init`, or the document would never have opened.
    public func resetVariantToAuto() {
        // Auto is what a parse still under way is already doing; the detection is a placeholder until it returns.
        guard !isAwaitingParse else { return }
        guard let reparsed = try? parse(data, variant: detection.variant) else { return }
        variant = Resolved(detection.variant, .detected)
        unquirkedDocument = reparsed
        document = quirkChoices.apply(to: reparsed)
        pixResults = DocumentPictures.resolve(reparsed, docPath: docPath)
        refreshPageSizeAfterReparse()
    }

    /// `.PIX` tags naming a picture the app could not find or read — a picture beside the document
    /// in a folder the app has not been given (#272 I8), or one that is really missing.
    public var unreadablePictureCount: Int {
        pixResults.filter { $0.error == .unresolved || $0.error == .unreadable }.count
    }

    /// Resolves the `.PIX` tags again against `docPath` — after the app has been given the folder
    /// the pictures live in (#272 I8). The parse is unchanged; only `pixResults` is recomputed.
    ///
    /// `linked: false` (batch 39, the iPhone's Unlink): every tag reads `.unresolved`, as it does for a
    /// document with no path to search from, whatever files sit beside the document.
    public func resolvePictures(linked: Bool = true) {
        pixResults = DocumentPictures.resolve(document, docPath: linked ? docPath : "")
    }

    /// The options Printed is laid out with for this document — the Margins choice and the
    /// resolved pictures — the same ones the Native renderer, the Printed view and Print build.
    public var printedOptions: EmitOptions {
        EmitOptions(pageSettings: pageSettingsPreset.value?.settings, pixResults: pixResults)
    }

    /// Document Info's Page Size, measured on the sheet Printed lays out (#271 M9): a `.pr or=l`
    /// document is rotated before anything is measured, so REF/BOOKLET.RJS (`.pl 8.5"`) reads
    /// "US Letter, landscape (11 × 8.5 in)" rather than a portrait sheet 8.5 in tall. A portrait
    /// sheet keeps its named size, or its height when it has no app-side name.
    public var pageSizeDescription: String {
        let metrics = printedMetrics(document, options: printedOptions)
        if metrics.pageWidth > metrics.pageHeight {
            let inches = String(format: "%g × %g in", metrics.pageWidth / 72, metrics.pageHeight / 72)
            let named = NamedPageSize.allCases.first {
                abs($0.sizeInPoints.width - metrics.pageHeight) <= 1 && abs($0.sizeInPoints.height - metrics.pageWidth) <= 1
            }
            return named.map { "\($0.displayName), landscape (\(inches))" } ?? "\(inches), landscape"
        }
        if let named = pageSize.value { return named.dimensionDescription }
        if let page = document.page { return String(format: "%.2f in tall (custom)", page.heightIn) }
        return "—"
    }

    /// Document Info's Margins: top and left from the Printed geometry, bottom from the page's
    /// `.mb` line count in WordStar's 1/48-inch leading — on the same rotated, preset-applied page
    /// the Page Size row reads (#271 M9). WordStar has no right-margin command, so there is no
    /// fourth figure.
    public var marginsDescription: String {
        guard document.page != nil, let page = printedDocument(document, options: printedOptions).page else { return "—" }
        let metrics = printedMetrics(document, options: printedOptions)
        return String(format: "Top %.1fin  Bottom %.1fin  Left %.1fin",
                      metrics.top / 72.0, page.mbLines * page.lh48 / 48.0, metrics.left / 72.0)
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

    public func setPageSize(_ newSize: NamedPageSize) {
        pageSize.setManually(newSize)
    }

    /// `nil` returns to "Embedded" — the app's default, not a manual choice of "no
    /// override" (mirrors `resetVariantToAuto()`'s use of `.detected` rather than `.manual`
    /// for going back to the detector's own answer).
    public func setPageSettingsPreset(_ preset: DocumentOperations.PageSettingsPreset?) {
        if let preset {
            pageSettingsPreset.setManually(preset)
        } else {
            pageSettingsPreset = Resolved(nil, .default)
        }
    }
}
