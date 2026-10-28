import CtrlKD
import Foundation
import SoftReturnShared

/// Batch 28 (#271 M10): a Quick Look request's engine half — the parse (`DocumentState.parsed`) and the engine's
/// pagination of it (`NativeEngineWork`) — with no AppKit, no UIKit and no actor, so an extension makes it on its own
/// request queue and takes the main thread only for the text, the layout and the drawing.
///
/// Batch 29 (#272 I12): shared by the Mac's extensions (`QuickLookNativeRenderer`) and the iPhone's
/// (`IOSQuickLookRenderer`), which draw the same render with their own views. Part of the renderer, beside
/// `DocumentRenderer`, which it renders through.
public struct QuickLookEngineWork: Sendable {
    public let bytes: [UInt8]
    public let docPath: String
    public let pageSettingsPreset: DocumentOperations.PageSettingsPreset?
    public let parsed: DocumentState.Parsed
    public let engine: NativeEngineWork

    /// `make` with the app's own Quick Look defaults from the app group (`QuickLookPageSettingsPreference`): the
    /// page-settings preset and the default quirks. What the extensions render with on both platforms. `defaults`:
    /// the app group's suite, or a test's own.
    public static func makeWithAppDefaults(
        bytes: [UInt8],
        docPath: String,
        defaults: UserDefaults? = QuickLookPageSettingsPreference.groupDefaults
    ) throws -> QuickLookEngineWork {
        try make(bytes: bytes, docPath: docPath,
                 pageSettingsPreset: QuickLookPageSettingsPreference.resolvedDefault(defaults: defaults),
                 quirks: QuickLookPageSettingsPreference.resolvedQuirkDefaults(defaults: defaults))
    }

    /// `pageSettingsPreset`: the Margins preset to paginate with; `quirks`: the quirks to parse with.
    public static func make(
        bytes: [UInt8],
        docPath: String,
        pageSettingsPreset: DocumentOperations.PageSettingsPreset?,
        quirks: QuirkChoices = .shipped,
        printedBy: PrintedBy = QuickLookPageSettingsPreference.resolvedPrintedBy()
    ) throws -> QuickLookEngineWork {
        // Batch 46: `quirks`, the app's default quirks; `printedBy`, which WordStar prints a WS4 file.
        let parsed = try DocumentState.parsed(from: bytes, docPath: docPath, quirks: quirks, printedBy: printedBy)
        // `DocumentRenderer.nativeEngineOptions` of the state `QuickLookRender.nativeState(for:)` makes: the preset's
        // settings and the pictures resolved with the parse; `pictures: true`, `render`'s export flags.
        let options = EmitOptions(pageSettings: pageSettingsPreset?.settings, pixResults: parsed.pixResults)
        return QuickLookEngineWork(bytes: bytes, docPath: docPath, pageSettingsPreset: pageSettingsPreset,
                                   parsed: parsed,
                                   engine: NativeEngineWork.make(document: parsed.document, options: options,
                                                                 pictures: true))
    }
}

/// The document a Quick Look request draws, made from its `QuickLookEngineWork`: page 1 alone for a thumbnail, every
/// page for a preview. The views that draw it are each platform's own.
@MainActor
public enum QuickLookRender {
    /// The document `work` was parsed from, in the state `QuickLookNativeRenderer.renderedDocument` renders it in: a
    /// placeholder with the parse adopted (`DocumentState.adopt` sets detection, variant, parse, pictures and page size
    /// exactly as `init(data:)` does), Native, and the preset `work` was paginated with. A fresh, ephemeral
    /// `SettingsStore` — an extension has no reason to read the app's preferences.
    public static func nativeState(for work: QuickLookEngineWork) -> DocumentState {
        CourierPrimeFontRegistration.registerIfNeeded()
        let ephemeralDefaults = UserDefaults(suiteName: "QuickLookRender.\(UUID().uuidString)")
            ?? UserDefaults.standard
        let state = DocumentState(awaitingParseOf: work.bytes, settings: SettingsStore(defaults: ephemeralDefaults),
                                  docPath: work.docPath)
        state.setQuirkDefaults(work.parsed.quirks)
        state.adopt(work.parsed)
        state.style.setManually(.native)
        if let preset = work.pageSettingsPreset {
            state.setPageSettingsPreset(preset)
        }
        return state
    }

    /// Page 1 ONLY: the engine paginated the whole document (`work`), the session builds page 1's text, and the
    /// snapshot is a one-page document. A thumbnail never builds a long document's other pages (b28-ql-measure).
    public static func pageOne(for work: QuickLookEngineWork) -> RenderedDocument {
        let session = DocumentRenderer.nativeRenderSession(nativeState(for: work), engine: work.engine)
        session.renderNext(1)
        return session.isComplete ? session.snapshot(final: true) : session.snapshot()
    }

    /// Every page — `DocumentRenderer.render(_:style: .native)` of the same state, from the work made already.
    public static func whole(for work: QuickLookEngineWork) -> RenderedDocument {
        let session = DocumentRenderer.nativeRenderSession(nativeState(for: work), engine: work.engine)
        session.renderAll()
        return session.snapshot(final: true)
    }
}
