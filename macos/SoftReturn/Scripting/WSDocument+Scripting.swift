import AppKit
import CtrlKD

/// The `document` class's scripting properties — `SoftReturn.sdef`'s `<cocoa key="...">`
/// targets, one per row of the dictionary's property table. Every property reads and
/// writes through `DocumentState`/`DocumentWindowController`, the SAME state the View
/// menu and bottom bar drive — never a second, scripting-only copy — so `set variant of
/// document 1 to ws4` visibly re-renders the window exactly like Edit ▸ Change Variant
/// does, and a script reading `zoom` sees what the bottom bar shows.
///
/// `@objc dynamic`, not a plain Swift property: Cocoa's scripting KVC bridge dispatches
/// through the Objective-C runtime, which only sees `@objc dynamic` members. Enumerated
/// properties (`variant`, `style`, `page size`, the named half of `zoom`) are typed
/// `NSNumber` wrapping the sdef enumerator's four-char code
/// (`ScriptingEnumCoding`/`ScriptingCodes`) — the representation Cocoa Scripting's
/// `typeEnumerated` boxes on the way in and out.
extension WSDocument {
    /// The window this document is showing through, when one exists. Always present for a
    /// document a script can see `document 1` of — `NSDocumentController` only lists
    /// documents that finished `makeWindowControllers()` — `nil` only protects the `#if
    /// DEBUG` test seam (`setStateForTesting`), which never attaches a window.
    private var scriptingWindowController: DocumentWindowController? {
        windowControllers.first as? DocumentWindowController
    }

    // MARK: - variant

    @objc dynamic var scriptingVariant: NSNumber {
        get { ScriptingCodes.nsNumber(ScriptingEnumCoding.variantCodes[state.variant.value] ?? "") }
        set {
            guard let variant = ScriptingEnumCoding.variant(forCode: newValue.uint32Value) else { return }
            if let controller = scriptingWindowController {
                controller.setVariant(variant)
            } else {
                state.setVariant(variant)
            }
        }
    }

    // MARK: - style

    /// Job 313B (Jon's ruling 2026-08-14, superseding job 265): the sdef's `style`
    /// enumeration is three-case now (`native`/`printed`/`modern`), matching `ViewStyle`
    /// directly — the old two-case collapse existed only because the enumerator had no
    /// `native` slot to report through; now that it does, reading reports whatever the
    /// window actually shows, honestly, and setting `native` switches the view exactly like
    /// View ▸ Native does, the same path `controller.setStyle` already gives the View menu.
    @objc dynamic var scriptingStyle: NSNumber {
        get { ScriptingCodes.nsNumber(ScriptingEnumCoding.styleCodes[state.style.value] ?? "") }
        set {
            guard let style = ScriptingEnumCoding.style(forCode: newValue.uint32Value) else { return }
            if let controller = scriptingWindowController {
                controller.setStyle(style)
            } else {
                state.style.setManually(style)
            }
        }
    }

    // MARK: - page count (read-only)

    @objc dynamic var scriptingPageCount: Int {
        if let controller = scriptingWindowController { return controller.pageTotal }
        // No live controller to fall back on (a KVC property read, not a command — there is
        // no `scriptErrorNumber` surface for it), and this document already parsed
        // successfully once to exist at all, so a re-pagination failure here is an edge case
        // with nothing better to report than the same sound default `DiagnosisResult`'s own
        // (nil-tolerant) page count uses.
        return (try? DocumentOperations.pageCount(data: state.data, variant: state.variant.value)) ?? 1
    }

    // MARK: - current page

    /// 1-based, matching the Go to Page sheet's own numbering — `goToPage(index:)` is
    /// 0-based internally.
    @objc dynamic var scriptingCurrentPage: Int {
        get { (scriptingWindowController?.currentPage ?? 0) + 1 }
        set { scriptingWindowController?.goToPage(index: newValue - 1) }
    }

    // MARK: - zoom (fit / actual size / a percentage number)

    /// A bare number this large never collides with a real zoom percentage, so decoding a
    /// dual-typed argument by comparing its magnitude against the enumerator codes (rather
    /// than needing a type tag Cocoa Scripting does not give this property) is safe in
    /// practice — see `ScriptingEnumCoding.namedZoom(forCode:)`.
    @objc dynamic var scriptingZoom: NSNumber {
        get {
            switch state.zoom.value {
            case .fit: return ScriptingCodes.nsNumber("SRzf")
            case .actual: return ScriptingCodes.nsNumber("SRza")
            case .percent(let pct): return NSNumber(value: pct)
            }
        }
        set {
            let setting: ZoomSetting
            if let named = ScriptingEnumCoding.namedZoom(forCode: newValue.uint32Value) {
                setting = named
            } else {
                setting = .percent(newValue.intValue)
            }
            if let controller = scriptingWindowController {
                controller.setZoom(setting)
            } else {
                state.zoom.setManually(setting)
            }
        }
    }

    // MARK: - page size

    @objc dynamic var scriptingPageSize: NSNumber {
        get {
            guard let size = state.pageSize.value,
                  let code = ScriptingEnumCoding.pageSizeCodes[size]
            else { return NSNumber(value: 0) }
            return ScriptingCodes.nsNumber(code)
        }
        set {
            guard let size = ScriptingEnumCoding.pageSize(forCode: newValue.uint32Value) else { return }
            if let controller = scriptingWindowController {
                controller.setPageSize(size)
            } else {
                state.setPageSize(size)
            }
        }
    }

    // MARK: - modern font / modern size

    @objc dynamic var scriptingModernFont: String {
        get { state.modernFontName }
        set {
            state.modernFontName = newValue
            scriptingWindowController?.rerender()
        }
    }

    @objc dynamic var scriptingModernSize: NSNumber {
        get { NSNumber(value: state.modernFontSize) }
        set {
            state.modernFontSize = newValue.intValue
            scriptingWindowController?.rerender()
        }
    }

    // MARK: - show invisibles

    @objc dynamic var scriptingShowInvisibles: Bool {
        get { state.showInvisibles }
        set {
            state.showInvisibles = newValue
            scriptingWindowController?.rerender()
        }
    }

    // MARK: - export (job 254, `export-specifier`)

    /// `SoftReturn.sdef`'s `export` command, bound to this class via `<responds-to>`
    /// rather than a `<cocoa class="...NSScriptCommand">` command binding — see
    /// `ExportCommand`'s header for why. Cocoa resolves the direct parameter's specifier
    /// to find the receiver (this document) before calling this method, so — unlike the
    /// old `performDefaultImplementation()` — there is no `directParameter` to cast; the
    /// receiver already IS the document.
    @objc func handleExportScriptCommand(_ command: NSScriptCommand) -> Any? {
        do {
            let settings = SettingsStore.shared
            let args = try ExportCommand.decode(
                arguments: command.evaluatedArguments ?? [:],
                documentStyle: state.style.value,
                defaultHeaders: settings.defaultHeaders, defaultTOC: settings.defaultTOC,
                defaultInlineStyling: settings.defaultInlineStyling,
                defaultPictures: settings.defaultPictures,
                defaultPageNumbers: settings.defaultPageNumbers)

            let basename = fileURL?.deletingPathExtension().lastPathComponent ?? ""
            let bytes: [UInt8]
            // Job 313B: "using style native" on a PDF export means the print-path PDF from
            // job 313A (Task A), the same `ExportEngine` route the Export As sheet uses for
            // a Native window — everything else (every other format, and PDF under any other
            // style) keeps going through the library's own `DocumentOperations.convert`,
            // unchanged from before this job.
            if args.format == ExportFormat.pdf.libraryFormatName, args.viewStyle == .native {
                let products = try ExportEngine.render(
                    document: state.document, state: state, formats: [.pdf],
                    notes: NoteSelection(), style: .printed, viewStyle: .native, title: basename,
                    docPath: fileURL?.path ?? "",
                    headers: args.headers, toc: args.toc, inlineStyling: args.inlineStyling,
                    pictures: args.pictures, pageNumbers: args.pageNumbers,
                    sentenceSpacing: args.sentenceSpacing)
                guard let product = products.first else { throw ExportCommand.DecodeError.unknownFormat }
                bytes = product.bytes
            } else {
                // fontsTarget defaults to `.mac` (mistake-registry #24: a Mac app's
                // user-facing RTF fonttbl defaults to the mac mapping, never the library's
                // `.office` default) but is no longer pinned there — job 504's `fonts`
                // parameter lets a script override it via `args.fontsTarget`.
                let options = DocumentOperations.ConversionOptions(
                    formats: [args.format], mode: args.mode, variant: state.variant.value,
                    title: basename, notes: args.notes, styles: args.styles,
                    fontsTarget: args.fontsTarget, pageSettings: args.pageSettings,
                    noteRefs: args.noteRefs, docPath: fileURL?.path ?? "",
                    headers: args.headers, toc: args.toc, inlineStyling: args.inlineStyling,
                    pictures: args.pictures, lineNumbers: args.lineNumbers,
                    pageNumbers: args.pageNumbers, sentenceSpacing: args.sentenceSpacing)
                let converted = try DocumentOperations.convert(data: state.data, options: options)
                guard let product = converted.first else { throw ExportCommand.DecodeError.unknownFormat }
                bytes = product.bytes
            }

            // Job 504: never clobber a pre-existing file at the requested destination — see
            // `ExportCommand.uniqueDestination`'s own doc comment for the ruling. The result
            // is the file actually written, not necessarily `args.destination`.
            let destination = ExportCommand.uniqueDestination(for: args.destination) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            try Data(bytes).write(to: destination, options: .atomic)
            return destination as NSURL
        } catch {
            command.scriptErrorNumber = NSInternalScriptError
            command.scriptErrorString = error.localizedDescription
            return nil
        }
    }
}
