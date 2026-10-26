#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import CtrlKD
import SoftReturnShared

@MainActor
public enum DocumentRenderer {
    /// Job 375 item C2 (b24 completion): the export-only overrides `appKitRenderedPDF` needs
    /// to honor the SAME `EmitOptions` the library's own emitters read — `render(_:style:)`'s
    /// own default (`.allOn`) reproduces every existing caller's current behavior exactly
    /// (the live document window has no per-window "hide headers" concept; only an EXPORT
    /// can ask for that), so every caller that predates this struct is unaffected. Not
    /// `EmitOptions` itself: this only ever gates the three flags with a real mechanism in
    /// the AppKit render path (headers/pictures/inline colour) — `toc` is handled entirely
    /// in `ExportEngine.appKitRenderedPDF` by appending extra pages, never inside the core
    /// render functions below.
    public struct ExportFlags: Sendable {
        public var headers = true
        public var pictures = true
        public var inlineStyling = true
        public static let allOn = ExportFlags()

        public init(headers: Bool = true, pictures: Bool = true, inlineStyling: Bool = true) {
            self.headers = headers
            self.pictures = pictures
            self.inlineStyling = inlineStyling
        }
    }

    /// Render `state`'s document in its current style, or `style` when the caller needs a
    /// different one without perturbing the window's own on-screen state (job 244 Leg 3: the
    /// Export panel's Style control renders whatever it says, defaulting to — but not forced
    /// to track — the window's live style).
    ///
    /// This function only ever draws through AppKit, so the default projects `state.style`
    /// (job 265's three-case `ViewStyle`) onto its two-case `RenderStyle` axis via
    /// `ViewStyle.renderStyle` — Native and Printed both mean the SAME facsimile layout here
    /// (Printed's own PDFKit rendering is a totally different code path, `pdfView` in
    /// `DocumentWindowController`, which never calls this function at all). Every real
    /// caller that cares about the distinction (`DocumentWindowController`,
    /// `QuickLookNativeRenderer`) passes `style` explicitly rather than relying on this.
    ///
    /// NEVER consults `state.showInvisibles` — this is the plain layout every non-screen
    /// caller (`ExportEngine`, `makePrintOperation`, `QuickLookNativeRenderer`,
    /// `PagePreviewRenderer`) calls, several of them against the SAME live `DocumentState`
    /// the document window shares, so Show Invisibles staying screen-only depends on this
    /// function never branching on that flag. See `renderWithInvisibles` below (the one
    /// caller that DOES want the annotated layout) and
    /// `showInvisiblesNeverReachesPrintedExportBytes`/`showInvisiblesAnnotatedOnlyOnScreen`
    /// (`WiringTests.swift`), which exist to catch a future regression of exactly this.
    public static func render(_ state: DocumentState, style: RenderStyle? = nil,
                       exportFlags: ExportFlags = .allOn) -> RenderedDocument {
        switch style ?? state.style.value.renderStyle {
        case .native: return renderNative(state, exportFlags: exportFlags)
        case .modern: return renderModern(state, exportFlags: exportFlags)
        }
    }

    /// Job 256 (Show Invisibles, part 2/4): Native style with WordStar's five invisible-ink
    /// classes (dot commands, comments, style toggles, soft/hard returns, page-break origin)
    /// rendered inline as real, faint text, via `CtrlKD.annotatedLayout`. Screen-only — the
    /// ONLY call site is `DocumentWindowController.reloadContent()`, gated on
    /// `documentState.showInvisibles`; every export/print/QuickLook path keeps calling
    /// `render(_:style:)` above, untouched by this function's existence.
    ///
    /// Job 294 (Jon's ruling): Modern now shows invisibles too, via `renderModernAnnotated`
    /// below — a DIFFERENT mark selection than Native's, not the same annotated layout
    /// reused verbatim (see that function's own doc comment for the differences: no
    /// soft-return marks ever, and a page break is a faint inline annotation, never a real
    /// page split). Printed (job 265's PDFKit mode) never reaches this function in practice
    /// — the View menu disables Show Invisibles while Printed is active — but a plain
    /// facsimile layout is the least-surprising thing to hand back should a caller ever slip
    /// through anyway.
    public static func renderWithInvisibles(_ state: DocumentState) -> RenderedDocument {
        switch state.style.value {
        case .native:  return renderNativeAnnotated(state)
        case .modern:  return renderModernAnnotated(state)
        case .printed: return render(state, style: .native)
        }
    }
}
